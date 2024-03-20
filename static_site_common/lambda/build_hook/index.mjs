import { SNSClient, PublishCommand } from '@aws-sdk/client-sns';

export const handler = async (event) => {
  console.log(JSON.stringify(event));

  const detail = event['detail'];
  const project = detail['project-name'];
  const status = detail['build-status'];
  const id = detail['build-id'].match(/.*\/.*?:(.*)/)[1];
  
  const subject = `${project}: ${status} (${id})`;
  console.log(subject);

  const client = new SNSClient({});
  const response = await client.send(new PublishCommand({
    TopicArn: process.env.TARGET_TOPIC_ARN,
    Subject: subject,
    Message: JSON.stringify(event),
  }));
  console.log(response);

  return response;
};
